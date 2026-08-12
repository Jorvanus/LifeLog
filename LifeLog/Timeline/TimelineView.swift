import SwiftUI
import SwiftData
import MapKit
import UIKit

struct TimelineView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let recorder: LocationRecorder
    @Binding var returnStartedAt: Date?
    // Imported journals already contain resolved activity/location pairs and never
    // participate in live movement reconciliation. Excluding them keeps the launch
    // timeline query lightweight.
    //
    // motion/health-walking are deliberately NOT excluded here, even though most of
    // them end up absorbed into a destination rather than shown: `rows(from:day:now:)`
    // below already asks `shouldShowInTimeline` that exact question per row, and it
    // can tell a walk absorbed into a stay apart from a genuine journey between two
    // places (`isBetweenDestinations`) — a query-level exclusion cannot, since it
    // discards a row before that check ever runs. Tried once (2026-08-09) to avoid
    // loading a large archive's worth of samples just to render one day; it also
    // silently hid every real standalone walk, which is exactly what
    // `testTimelineShowsTheOvernightStayAndTheWalkBetweenPlaces` and
    // `testAWalkWithNoPositionShowsThePlacesEitherSideOfIt` exist to catch. The
    // The fetch below is date-scoped; excluding by source remains the wrong tool for
    // deciding whether a movement record belongs on the day's journey.
    @Query private var visits: [Visit]
    @State private var adding = false
    @State private var clock = Date.now
    /// The day being read. Today until the person moves off it, at which point the
    /// screen stops being a live view and becomes the journal it always held.
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var jumpingToDate = false
    @State private var draftSelectedDay = Calendar.current.startOfDay(for: .now)
    /// The first day there is anything to read, so the picker cannot offer years of
    /// empty days before the archive begins. Resolved once, from one row.
    @State private var earliestDay: Date?
    // The add button's glyph and its circle have to grow together, otherwise a
    // Dynamic Type glyph overflows a fixed-size circle at accessibility sizes.
    @ScaledMetric(relativeTo: .title2) private var addButtonDiameter: CGFloat = 56
    // Bump this marker whenever reconciliation learns a new rule, so an installed
    // timeline is repaired once rather than only new records benefiting. v5 held a
    // stay open until the journey that left it; v6 exists because v5 never ran — the
    // marker below was written even when the repair was skipped for an unloaded query,
    // so bumping the key alone could not recover it.
    // v9: WorkoutJourneys' no-route fallback stopped exempting "learned"/"confirmed"
    // stays outright (2026-08-09) — a stay already stuck in the review queue under the
    // old rule needs this pass to run again to be re-evaluated; it will not clear on
    // its own, since the workout's HKWorkout sample was already delivered once and an
    // anchored query does not redeliver it without a Health re-import.
    // v10: workout-vs-movement absorption (2026-08-09) — a week of walks recorded twice
    // over by health-walking/motion alongside health-workout needs this pass to clean
    // up the backlog once; new walks are covered going forward by the recent-day
    // re-apply, which does not reach anything already sitting in the store.
    // v11: boundStays stopped letting a workout's own lead-in steps bind a stay's
    // departure ahead of the workout itself (2026-08-09) — the same backlog reasoning
    // as v10 applies: a walk from days ago that opened a few minutes early under the
    // old rule needs this pass to run again, not just the recent-day re-apply.
    // v12: Core Motion can briefly stop calling an ongoing drive automotive. Rejoin
    // those short gaps once so old trips do not remain as several fragments.
    @AppStorage("location-policy-reconciled-v12") private var locationPolicyReconciled = false
    // Undoes the stays v3 split in two before reconciliation runs again.
    @AppStorage("stay-splits-rejoined-v1") private var staySplitsRejoined = false
    // Puts back together the workouts the import path used to cut up at stay boundaries.
    @AppStorage(WorkoutJourneys.splitWorkoutRepairKey) private var splitWorkoutsRepaired = false
    // Bump this marker whenever de-duplication rules become stronger so an
    // installed timeline receives the one-time repair as well as new callbacks.
    @AppStorage("automatic-location-deduplicated-v3") private var automaticLocationDeduplicated = false
    // Merges the duplicate sleep visits the pre-fix arrival-window bug could
    // leave behind. New duplicates should no longer occur, so this runs once.
    @AppStorage(SleepSessionRepair.repairKey) private var sleepDuplicatesMerged = false

    init(recorder: LocationRecorder, returnStartedAt: Binding<Date?> = .constant(nil)) {
        self.recorder = recorder
        _returnStartedAt = returnStartedAt
        // Today needs a small lead-in for an overnight stay, not the full archive.
        let start = Calendar.current.date(byAdding: .day, value: -7, to: Date.now) ?? .now
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Date.now) ?? .now
        _visits = Query(
            filter: #Predicate { visit in
                // An open stay may have begun before the usual lead-in. Keep that one
                // live record so a long trip or an interrupted departure never makes
                // the current-location card disappear just because it is old.
                visit.source != "imported-journal" &&
                    (visit.arrival >= start || visit.departure == nil) && visit.arrival < end
            },
            sort: [SortDescriptor(\Visit.arrival, order: .reverse)]
        )
    }

    private var today: [Visit] {
        TimelineView.rows(from: visits, day: TimelineView.interval(of: clock), now: clock)
    }

    /// The day a date falls in, as an interval.
    static func interval(of date: Date) -> DateInterval {
        let start = Calendar.current.startOfDay(for: date)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        return DateInterval(start: start, end: max(start, end))
    }

    /// What a day's journey shows, from the visits available for it.
    ///
    /// Static and parameterised by day so today's live screen and any past day are
    /// filtered by one implementation rather than two that would drift.
    static func rows(from visits: [Visit], day: DateInterval, now: Date) -> [Visit] {
        let locationVisits = visits.filter(ActivityLocationPolicy.isLocationVisit)
        // A day is what it covered, not what began in it. Selecting by arrival date
        // dropped the overnight stay, so the day appeared to start at the first
        // outing rather than at home.
        return visits.filter { ActivityLocationPolicy.covers($0, day: day, now: now) }
            .filter { $0.resolutionState != .ignored && $0.resolutionState != .superseded }
            .filter { ActivityLocationPolicy.shouldShowInTimeline($0, locationVisits: locationVisits, now: now) }
            // Core Location can replay an older unknown callback after a later
            // named visit arrives. Do not show that stale review row when its
            // interval is covered by a more useful location record.
            .filter { visit in
                guard visit.needsCategorisation else { return true }
                let end = visit.departure ?? now
                return !locationVisits.contains { other in
                    guard other.id != visit.id, !other.needsCategorisation else { return false }
                    let otherEnd = other.departure ?? now
                    return other.arrival <= end && otherEnd > visit.arrival
                }
            }
            .filter { visit in
                // Health and Motion can emit a short workout plus a longer
                // duplicate with the same start. Keep the more precise sample
                // when one interval is fully contained by another.
                guard ActivityLocationPolicy.isDeviceActivity(visit),
                      !SleepEvidence.isSleepSource(visit.source) else { return true }
                let end = visit.departure ?? now
                return !visits.contains { other in
                    guard other.id != visit.id,
                          ActivityLocationPolicy.isDeviceActivity(other),
                          !SleepEvidence.isSleepSource(other.source),
                          other.activity.caseInsensitiveCompare(visit.activity) == .orderedSame else { return false }
                    let otherEnd = other.departure ?? now
                    let contains = other.arrival <= visit.arrival && otherEnd >= end
                    let strictlyBroader = other.arrival < visit.arrival || otherEnd > end
                    // Motion and Health can describe the same walk over exactly the
                    // same interval, and whether the import guard caught it depends on
                    // which batch arrived first. Neither record is broader, so prefer
                    // the more specific source rather than showing the walk twice.
                    let sameInterval = other.arrival == visit.arrival && otherEnd == end
                    return contains && (strictlyBroader ||
                                        (sameInterval && deviceDetail(other) > deviceDetail(visit)))
                }
            }
    }
    /// How much a source actually knows about a walk. A recorded workout carries the
    /// person's own intent, Health's walking samples come from the watch, and Core
    /// Motion is an inference from the phone alone.
    private static func deviceDetail(_ visit: Visit) -> Int {
        switch visit.source {
        case "health-workout": 3
        case "health-walking": 2
        default: 1
        }
    }

    private var reviewQueue: [ReviewQueue.Entry] {
        // The live unknown location has its own prominent card; the queue is for past stays.
        ReviewQueue.entries(in: visits, now: clock).filter { $0.visit.departure != nil }
    }
    private var current: Visit? {
        visits.first { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored && $0.departure == nil }
    }

    private var isWaitingForVisitConfirmation: Bool {
        guard current == nil, recorder.latestLocationTimestamp != nil else { return false }
        return recorder.authorization == .authorizedAlways || recorder.authorization == .authorizedWhenInUse
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lifeBackground.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        // The greeting, the date and the review queue are all about now.
                        // On a past day they would sit above a different date entirely,
                        // so the screen drops them and becomes what it is being used as:
                        // a reader for one day of the journal.
                        if isShowingToday {
                            header
                            if let review = reviewQueue.first { reviewCard(review) }
                        }
                        journey
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 36)
                }
            }
            .accessibilityIdentifier("timeline-screen")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $adding) { ManualVisitView(range: TimelineView.interval(of: selectedDay)) }
            .sheet(isPresented: $jumpingToDate) { jumpToDateSheet }
            .onAppear {
                if let returnStartedAt {
                    Diagnostics.budget(context, subsystem: "Timeline", operation: "return to Timeline",
                                       startedAt: returnStartedAt,
                                       budget: Diagnostics.PerformanceBudget.returnToTimeline)
                    self.returnStartedAt = nil
                }
            }
            .task {
                loadEarliestDay()
                // Let SwiftUI paint the first interactive frame before historical
                // resolver and catch-up work resumes when returning from another tab.
                await Task.yield()
                // Store opening and every callback/import mutation already resolve
                // the timeline. Re-running the archive-wide resolver merely because
                // this tab became visible made a Settings round-trip block for seconds.
                // Each repair below can touch a meaningful slice of a large archive.
                // Yielding between them, not just once at the very top, lets the run
                // loop interleave a frame — the tab bar's own selection animation
                // included — instead of this whole chain landing as one uninterrupted
                // block on the main actor every time Timeline appears.
                await Task.yield()
                if !automaticLocationDeduplicated {
                    do {
                        let removed = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
                        if removed > 0 { try context.save() }
                        automaticLocationDeduplicated = true
                    } catch {
                        // Retry after a protected-store failure on the next appearance.
                    }
                }
                await Task.yield()
                if !staySplitsRejoined {
                    do {
                        // Must run before reconciliation, which then re-absorbs the
                        // walk that had been sitting between the two halves.
                        let rejoined = try ActivityLocationPolicy.rejoinStaysSplitByMovement(context: context)
                        if rejoined > 0 {
                            try context.save()
                            Diagnostics.record(context, subsystem: "Core Location",
                                               message: "Rejoined \(rejoined) stays split by movement.", severity: "info")
                        }
                        staySplitsRejoined = true
                    } catch {
                        // Retry after a protected-store failure on the next appearance.
                    }
                }
                await Task.yield()
                if !splitWorkoutsRepaired {
                    do {
                        let repaired = try WorkoutJourneys.repairSplitWorkouts(context: context)
                        if repaired > 0 {
                            try context.save()
                            Diagnostics.record(context, subsystem: "Core Location",
                                               message: "Repaired \(repaired) workout rows split by a stay.",
                                               severity: "info")
                        }
                        splitWorkoutsRepaired = true
                    } catch {
                        // Retry after a protected-store failure on the next appearance.
                    }
                }
                await Task.yield()
                if !sleepDuplicatesMerged {
                    do {
                        let merged = try SleepSessionRepair.mergeDuplicates(context: context)
                        if merged > 0 {
                            Diagnostics.record(context, subsystem: "HealthKit",
                                               message: "Merged \(merged) duplicate sleep visits.",
                                               severity: "info")
                        }
                        sleepDuplicatesMerged = true
                    } catch {
                        // Retry after a protected-store failure on the next appearance.
                    }
                }
                // This migration-style cleanup used to scan the complete timeline on
                // every appearance. Large journal imports made that noticeable, so run
                // it once per installation/version; new visits are reconciled as they
                // arrive by LocationRecorder.
                // Before the guard, not after it. The first attempt at this reported
                // from inside the branch the marker protects, so an already-completed
                // marker returned in silence — indistinguishable from the block never
                // being reached, which is the one thing it was meant to tell apart.
                // Reports the value itself, not just whether the pass ran. The repair is
                // now known to apply and save — the log says so — and to be gone
                // afterwards, so what matters is *when* it reverts. Printing the stay's
                // departure on every appearance turns that into something watchable
                // instead of something to reason about.
                await Task.yield()
                let watched = visits
                    .filter { ActivityLocationPolicy.isLocationVisit($0) && $0.departure != nil }
                    .max { ($0.departure ?? .distantPast) < ($1.departure ?? .distantPast) }
                let watchedEnd = watched?.departure.map {
                    $0.formatted(date: .omitted, time: .standard)
                } ?? "none"
                Diagnostics.record(context, subsystem: "Timeline",
                                   message: "Reconciliation check: marker \(locationPolicyReconciled ? "set" : "unset"), "
                                          + "\(visits.count) visits, "
                                          + "\(visits.filter(ActivityLocationPolicy.isDeviceActivity).count) from a device, "
                                          + "latest closed stay ends \(watchedEnd).",
                                   severity: "info")
                // Always, not once. A one-shot repair loses to the import actor's own
                // context, which saves stale copies of the same visits a moment later.
                //
                // Absorption before journey timing, not after: journey timing calls
                // boundStays, which decides a lead-in health-walking record is not its
                // own excursion by checking how close it ends to a workout's start —
                // and that check reads the wrong answer against a record still carrying
                // its full, untrimmed, overlapping end. Absorption has to shorten it
                // first.
                await Task.yield()
                do {
                    if try ActivityLocationPolicy.reapplyRecentMovementAbsorption(context: context) {
                        Diagnostics.record(context, subsystem: "Timeline",
                                           message: "Absorbed movement a workout already accounted for.",
                                           severity: "info")
                    }
                } catch {
                    // Retried on the next appearance, like every other repair here.
                }
                await Task.yield()
                do {
                    if try ActivityLocationPolicy.reapplyRecentJourneyTiming(context: context) {
                        Diagnostics.record(context, subsystem: "Timeline",
                                           message: "Re-applied journey timing to the last day.",
                                           severity: "info")
                    }
                } catch {
                    // Retried on the next appearance, like every other repair here.
                }
                await Task.yield()
                do {
                    if try ActivityLocationPolicy.reapplyRecentOpenStayAbsorption(context: context) {
                        Diagnostics.record(context, subsystem: "Timeline",
                                           message: "Absorbed a burst orphaned by an import that ran before its stay existed.",
                                           severity: "info")
                    }
                } catch {
                    // Retried on the next appearance, like every other repair here.
                }
                guard !locationPolicyReconciled else { return }
                await Task.yield()
                do {
                    // Journal-only imports do not contain device activity, so there is
                    // nothing to reconcile. This cheap check avoids a second full-history
                    // pass immediately after importing a large archive.
                    //
                    // Returning rather than falling through to the marker is the whole
                    // point. `visits` is a @Query and this task can run before SwiftData
                    // has filled it, so an empty array means "not loaded yet" far more
                    // often than it means "nothing to do". Marking the repair done from
                    // that state is how a bump to this key could take effect on paper and
                    // never run: the flag was written, the work was not, and no later
                    // launch would try again. Every previous bump of this marker was
                    // capable of doing the same.
                    guard visits.contains(where: ActivityLocationPolicy.isDeviceActivity) else {
                        // Said out loud, because this is the branch that silently did
                        // nothing for two releases. `Diagnostics.performance` only records
                        // operations over 250ms, so a repair that runs in milliseconds —
                        // or never runs at all — left no trace either way, and the only
                        // way to tell them apart was to guess.
                        Diagnostics.record(context, subsystem: "Timeline",
                                           message: "Reconciliation deferred: \(visits.count) visits loaded, none from a device yet.",
                                           severity: "info")
                        return
                    }
                    let startedAt = Date.now
                    try ActivityLocationPolicy.reconcileAll(context: context)
                    try ActivityLocationPolicy.updateTravelDescriptions(context: context)
                    try context.save()
                    Diagnostics.performance(context, subsystem: "Timeline", operation: "activity reconciliation",
                                            startedAt: startedAt, itemCount: visits.count)
                    let afterSave = visits
                        .filter { ActivityLocationPolicy.isLocationVisit($0) && $0.departure != nil }
                        .max { ($0.departure ?? .distantPast) < ($1.departure ?? .distantPast) }
                    let afterEnd = afterSave?.departure.map {
                        $0.formatted(date: .omitted, time: .standard)
                    } ?? "none"
                    Diagnostics.record(context, subsystem: "Timeline",
                                       message: "Reconciliation ran over \(visits.count) visits; "
                                              + "latest closed stay now ends \(afterEnd).",
                                       severity: "info")
                    locationPolicyReconciled = true
                } catch {
                    // Leave the flag unset so a transient protected-store failure can
                    // be retried on the next appearance.
                }
            }
            // After the import, not before it. The import has its own store connection and
            // saves last, so a correction applied on appearance is overwritten within the
            // same second — which is exactly what the diagnostics recorded, twice. This
            // fires when the import announces it has finished, so the correction lands on
            // top of its write instead of underneath it.
            .onReceive(NotificationCenter.default.publisher(for: InsightsInvalidation.notification)) { _ in
                // Absorption first — see the matching note above.
                do {
                    if try ActivityLocationPolicy.reapplyRecentMovementAbsorption(context: context) {
                        Diagnostics.record(context, subsystem: "Timeline",
                                           message: "Absorbed movement a workout already accounted for, after an import.",
                                           severity: "info")
                    }
                } catch {
                    // Retried on the next import or appearance.
                }
                do {
                    if try ActivityLocationPolicy.reapplyRecentJourneyTiming(context: context) {
                        Diagnostics.record(context, subsystem: "Timeline",
                                           message: "Re-applied journey timing after an import.",
                                           severity: "info")
                    }
                } catch {
                    // Retried on the next import or appearance.
                }
                do {
                    if try ActivityLocationPolicy.reapplyRecentOpenStayAbsorption(context: context) {
                        Diagnostics.record(context, subsystem: "Timeline",
                                           message: "Absorbed a burst orphaned by an import that ran before its stay existed, after an import.",
                                           severity: "info")
                    }
                } catch {
                    // Retried on the next import or appearance.
                }
            }
            .task {
                // Refresh elapsed labels without polling Core Location or the store.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    clock = .now
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            // The greeting is decorative. At accessibility sizes the date is
                            // enough orientation and leaves the review and journey reachable.
                            Text(headerDate)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(greeting)
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                // Two lines with a lower floor: now that the greeting scales
                                // with Dynamic Type, a single line would ellipsize at
                                // accessibility sizes rather than wrap.
                                .lineLimit(2).minimumScaleFactor(0.7)
                            Text(headerDate)
                                .font(.title3).foregroundStyle(.secondary)
                        }
                    }
                    // The greeting and the date are decoration — they say nothing the
                    // person does not already know. At the largest accessibility sizes
                    // they filled a third of a 6.9" screen and pushed the day's journey
                    // off the bottom, so they stop growing where the content starts to
                    // suffer. The review count below is not capped: it is the one line
                    // here worth acting on.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    if !reviewQueue.isEmpty {
                        Text("\(reviewQueue.count) \(reviewQueue.count == 1 ? "place" : "places") to review")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                            // Without this the row shares its width with the add button
                            // and clips to a single line, so at accessibility sizes it
                            // read "1 place to r…" — the count survived and the thing
                            // being counted did not.
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
                Spacer()
                Button { adding = true } label: {
                    Image(systemName: "plus")
                        .font(.title2)
                        // Keep this a comfortable control, not a second headline. The
                        // glyph and circle still scale together up to this useful ceiling.
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .frame(width: min(addButtonDiameter, 64),
                               height: min(addButtonDiameter, 64))
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.04), radius: 12, y: 5)
                }.accessibilityLabel("Add visit")
            }
        }.padding(.top, dynamicTypeSize.isAccessibilitySize ? 8 : 20)
    }

    private func reviewCard(_ entry: ReviewQueue.Entry) -> some View {
        let visit = entry.visit
        return NavigationLink { VisitEditor(visit: visit) } label: {
            VStack(alignment: .leading, spacing: 17) {
                Label(dynamicTypeSize.isAccessibilitySize ? "Review" : "Review Queue",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                // At accessibility sizes the icon and action pill left the text column
                // so narrow that "Is this right?" wrapped one word to a line and ran
                // off the bottom of the screen. The card is already one link, so its
                // orange action cue is enough; the former chevron only duplicated it.
                let stacked = dynamicTypeSize.isAccessibilitySize
                let details = VStack(alignment: .leading, spacing: 4) {
                    // Each reason asks a different question. Agreeing with a weak
                    // guess, naming a place LifeLog knows nothing about, and saying
                    // whether you stopped at all are not the same request.
                    Text(entry.reason.prompt).font(.headline).foregroundStyle(.primary)
                    if entry.reason == .unidentified {
                        if !visit.hasPlaceholderName {
                            Text("Likely: \(visit.placeName)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(visit.placeName).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(entry.reason == .passingStay
                         ? "\(formattedDuration(visit.duration)) here, and you have not been back"
                         : "Suspected activity: \(visit.inferredActivity)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                let action = Text(entry.reason == .unidentified ? "Categorise" : "Check")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 9))

                if stacked {
                    details.frame(maxWidth: .infinity, alignment: .leading)
                    action.frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 14) {
                        ActivityIcon(activity: visit.activity, context: visit.displayPlaceName, color: .orange)
                        details
                        Spacer()
                        action
                    }
                }
            }
            .padding(18)
            .background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.orange.opacity(0.3)))
        }
        // This still supports roughly 200% text, while preventing one review card from
        // becoming several screens tall before the day's actual journey can begin.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .buttonStyle(.plain)
        .accessibilityIdentifier("uncategorised-location-card")
    }

    private func currentCard(_ visit: Visit) -> some View {
        NavigationLink { VisitEditor(visit: visit) } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Circle().fill(.green).frame(width: 10, height: 10)
                    Text("Current Activity").font(.headline.weight(.semibold)).foregroundStyle(.green)
                    Spacer()
                    if visit.needsCategorisation {
                        Label("Label", systemImage: "flag.fill")
                            .font(.caption.bold()).foregroundStyle(.orange)
                    } else if visit.needsConfirmation {
                        // A named guess is not the same as an unidentified one, but
                        // this card used to treat them identically -- a low-confidence
                        // Maps match (recognitionConfidence "low"/"medium") rendered
                        // with total certainty, no different from a place LifeLog was
                        // actually sure of. `needsConfirmation` already exists and
                        // already gates the "Yes, this is right?" prompt inside the
                        // editor; this is the one place that flag never reached.
                        Label("Confirm", systemImage: "questionmark.circle.fill")
                            .font(.caption.bold()).foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(visit.displayPlaceName).font(.title2.bold()).foregroundStyle(.primary)
                        if visit.needsCategorisation {
                            Text("Suspected activity: \(visit.inferredActivity)").foregroundStyle(.secondary)
                            if visit.placeName != "Identifying…" && visit.placeName != "Unknown place" {
                                Text("Likely place: \(visit.placeName)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if visit.needsConfirmation {
                            Text("Is this right? · \(visit.activity)").foregroundStyle(.secondary)
                        } else {
                            Text(visit.activity).foregroundStyle(.secondary)
                        }
                        Text("Since \(dayQualifiedTime(visit.arrival)) · \(elapsedVisitDuration(visit))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer()
                    ActivityScene(activity: visit.suspectedActivity, context: visit.displayPlaceName)
                }
            }
            .padding(20)
            .background(Color.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.green.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 14, y: 7)
        }.buttonStyle(.plain).accessibilityIdentifier("current-location-card")
    }

    /// A day that is over, read from the whole store rather than the live query.
    ///
    /// Its own `@Query` because the screen's main one excludes `imported-journal` to
    /// keep launch light, and nine years of archive is precisely what a past day is.
    /// Scoped to a window rather than the whole table so opening a day in 2017 costs
    /// the same as opening yesterday.
    private struct PastDayJourney: View {
        let day: Date
        @Query private var visits: [Visit]

        init(day: Date) {
            self.day = day
            let interval = TimelineView.interval(of: day)
            let end = interval.end
            // A stay is shown on every day it covers, so one that began earlier has to
            // be fetched to be found. A week reaches the overnight and weekend-long
            // stays without pulling the table in.
            let from = Calendar.current.date(byAdding: .day, value: -7, to: interval.start) ?? interval.start
            _visits = Query(
                filter: #Predicate<Visit> { $0.arrival < end && $0.arrival >= from },
                sort: [SortDescriptor(\Visit.arrival, order: .reverse)]
            )
        }

        var body: some View {
            let interval = TimelineView.interval(of: day)
            // Ended, so "now" is the end of that day: an unclosed stay must not be
            // measured against the present or it would run for years.
            let rows = TimelineView.rows(from: visits, day: interval, now: interval.end)
            if rows.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Nothing recorded on this day").font(.headline)
                    Text("Move to another day, or tap the date to jump.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(32).lifeCard()
                .accessibilityIdentifier("empty-day")
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, visit in
                        JourneyRow(visit: visit, isCurrent: false,
                                   isFirst: index == 0, isLast: index == rows.count - 1)
                    }
                }
            }
        }
    }

    private var isShowingToday: Bool {
        Calendar.current.isDate(selectedDay, inSameDayAs: clock)
    }


    /// The day being read, and the way to change it.
    ///
    /// A calendar, not arrows. Nine years is far too much history to step through a day
    /// at a time, so the only way in is to name the day you want. A swipe was tried and
    /// removed: attached to the scrolling content it fought that view's own drag, and a
    /// gesture that works only sometimes is worse than one that is not offered.
    private var dayNavigator: some View {
        HStack(spacing: 8) {
            Button {
                draftSelectedDay = selectedDay
                jumpingToDate = true
            } label: {
                HStack(spacing: 6) {
                    Text(isShowingToday ? "Today’s Journey" : journeyTitle)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                    // Says the title is a control. Without it a heading that happens to
                    // be tappable is indistinguishable from a heading that is not.
                    Image(systemName: "calendar")
                        .font(.headline).foregroundStyle(.blue)
                }
            }
            .accessibilityHint("Opens a calendar to pick a day")
            .accessibilityIdentifier("jump-to-date-button")

            Spacer(minLength: 4)

            if !isShowingToday {
                Button("Today") { selectedDay = Calendar.current.startOfDay(for: clock) }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("today-button")
            }
        }
        .buttonStyle(.plain)
        .tint(.blue)
    }

    private var journeyTitle: String {
        selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private var jumpToDateSheet: some View {
        NavigationStack {
            DatePicker("Jump to date",
                       selection: Binding(
                        get: { draftSelectedDay },
                        set: { draftSelectedDay = Calendar.current.startOfDay(for: $0) }
                       ),
                       in: (earliestDay ?? .distantPast)...Calendar.current.startOfDay(for: clock),
                       displayedComponents: .date)
            .datePickerStyle(.graphical)
            .padding()
            .navigationTitle("Jump to date")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("jump-to-date-sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { jumpingToDate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        selectedDay = draftSelectedDay
                        jumpingToDate = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The first day with anything in it, so the picker cannot offer years of empty
    /// days before the archive starts. One row, fetched once.
    private func loadEarliestDay() {
        guard earliestDay == nil else { return }
        var descriptor = FetchDescriptor<Visit>(sortBy: [SortDescriptor(\Visit.arrival, order: .forward)])
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.arrival]
        guard let first = try? context.fetch(descriptor).first else { return }
        earliestDay = Calendar.current.startOfDay(for: first.arrival)
    }

    private var journey: some View {
        VStack(alignment: .leading, spacing: 18) {
            dayNavigator
            if !isShowingToday {
                // A past day owns its own fetch: the query above deliberately excludes
                // the imported journal to keep launch light, and that archive is exactly
                // what a past day is made of.
                PastDayJourney(day: selectedDay)
            } else if today.isEmpty && current == nil && !isWaitingForVisitConfirmation {
                VStack(spacing: 14) {
                    Image(systemName: "location.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Your visits will appear here").font(.headline)
                    Text("Enable background logging in Settings or add a visit manually.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(32).lifeCard()
            } else {
                VStack(spacing: 12) {
                    if let current {
                        currentCard(current)
                    } else if isWaitingForVisitConfirmation {
                        waitingForVisitCard
                    }
                    let historicalVisits = today.filter { current?.id != $0.id }
                    ForEach(Array(historicalVisits.enumerated()), id: \.element.id) { index, visit in
                        JourneyRow(visit: visit, isCurrent: false,
                                   isFirst: current == nil && !isWaitingForVisitConfirmation && index == 0,
                                   isLast: index == historicalVisits.count - 1)
                    }
                }
            }
            // Under the day, not above it: what happened today comes first, and the
            // earlier years are what you read afterwards. Tapping one opens it.
            OnThisDaySection(day: selectedDay, earliest: earliestDay) { selectedDay = $0 }
        }
        // Deliberately no identifier on this container. One here propagates down and
        // *overrides* every child's own, so the day navigator's buttons and every
        // journey row all reported as "todays-journey" and none could be addressed by
        // the name it was given. The heading below carries the section's identifier.
    }

    private var waitingForVisitCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.green.opacity(0.12)).frame(width: 60, height: 60)
                ProgressView().tint(.green)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Current location").font(.headline.weight(.semibold))
                Text("Waiting for visit confirmation")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let timestamp = recorder.latestLocationTimestamp {
                    Text("Location received \(elapsedDescription(since: timestamp)) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(Color.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.green.opacity(0.3)))
        .accessibilityIdentifier("waiting-for-visit-confirmation")
        .accessibilityLabel("Current location, waiting for visit confirmation")
    }

    private func elapsedDescription(since date: Date) -> String {
        let seconds = max(0, Int(clock.timeIntervalSince(date)))
        let minutes = seconds / 60
        if minutes < 1 { return "just now" }
        if minutes == 1 { return "1 minute" }
        return "\(minutes) minutes"
    }

    private func elapsedVisitDuration(_ visit: Visit) -> String {
        let totalMinutes = max(0, Int(clock.timeIntervalSince(visit.arrival) / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<12: "Good Morning"
        case 12..<17: "Good Afternoon"
        default: "Good Evening"
        }
    }

    private var headerDate: String {
        let date = Date.now
        return "\(date.formatted(.dateTime.weekday(.wide))) \(date.formatted(.dateTime.day())) \(date.formatted(.dateTime.month(.wide)))"
    }
}

/// A span as a person would say it, rounded down to whole minutes.
func formattedDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int(seconds / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "\(minutes)m" }
    if minutes == 0 { return "\(hours)h" }
    return "\(hours)h \(minutes)m"
}

/// Distance as a person would say it: whole metres up to a kilometre, then one
/// decimal place, because "1.4 km" is a walk and "1,428 m" is a measurement.
func formattedDistance(_ metres: CLLocationDistance) -> String {
    metres < 1_000
        ? "\(Int(metres.rounded())) m"
        : String(format: "%.1f km", metres / 1_000)
}

/// Names the day a time fell on when it was not today. A night at home belongs to
/// this morning's timeline but began yesterday evening, and "6:12 pm – 7:20 am"
/// with no day would read as a stay of a few minutes.
private func dayQualifiedTime(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return time }
    if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
    return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
}

private struct JourneyRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let visit: Visit
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool
    private var color: Color { visit.needsCategorisation ? .orange : activityColor(visit.activity) }

    var body: some View {
        NavigationLink { VisitEditor(visit: visit) } label: {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 12) {
                    ActivityIcon(activity: visit.suspectedActivity, context: visit.displayPlaceName,
                                 color: color, size: 48)
                    VStack(alignment: .leading, spacing: 10) {
                        journeyDetails
                        Text(durationDescription)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        status
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .lifeCard()
            } else {
                HStack(spacing: 0) {
                    ZStack {
                        if !isFirst {
                            Rectangle().fill(Color.secondary.opacity(0.28)).frame(width: 2, height: 62).offset(y: -31)
                        }
                        if !isLast {
                            Rectangle().fill(Color.secondary.opacity(0.28)).frame(width: 2, height: 62).offset(y: 31)
                        }
                        Circle().fill(Color.lifeBackground).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(color, lineWidth: 2))
                            .overlay(Circle().fill(color).frame(width: 8, height: 8))
                    }.frame(width: 38).frame(minHeight: 108)
                    HStack(spacing: 14) {
                        ActivityIcon(activity: visit.suspectedActivity, context: visit.displayPlaceName,
                                     color: color, size: 48)
                        // layoutPriority, not maxWidth: .infinity -- the latter reserves
                        // a box sized off the *available* width, so a short name (most of
                        // them) rendered flush left inside it with visible dead space
                        // before the duration column, no matter how narrow that gap was
                        // asked to be. Priority instead makes this the last thing to
                        // shrink when a long name and the fixed-size duration/chevron
                        // are actually competing for room, so it still wraps under real
                        // contention, but a short name simply renders at its own width.
                        journeyDetails.layoutPriority(1)
                        // The Spacer -- not journeyDetails -- owns whatever's left after
                        // that, so it collapses to nothing for a long name (right up
                        // against the text, no forced gap) and keeps the duration/chevron
                        // pinned to the card's actual right edge for a short one, rather
                        // than stranding unclaimed width after the chevron instead.
                        Spacer(minLength: 0)
                        // Contention with the now-higher-priority text above must
                        // shrink journeyDetails first, not break "Medium" or "7h 25m"
                        // across two lines -- fixedSize pins this to its own single-line
                        // width regardless of how little room is left.
                        VStack(alignment: .trailing, spacing: 8) {
                            Text(durationDescription)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            status
                        }
                        .fixedSize()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    // journeyDetails below is .fixedSize(vertical:) so a long place
                    // name wrapping to 2-3 lines grows past 108pt -- this used to be
                    // a hard `height: 108` on both the card and the dot/line column
                    // at left, so a tall card's dot stayed pinned where a 108pt row
                    // would have centred it, floating near the top instead of the
                    // middle. `minHeight` lets both grow together and keeps the
                    // common (single/double-line) case pixel-identical.
                    //
                    // The outer maxWidth: .infinity is what actually makes the card
                    // span the row's full available width -- the HStack above, left on
                    // its own, only ever sizes to its content, whatever the ScrollView
                    // around it can offer. Left-alignment then puts any width beyond
                    // that content after the chevron, as ordinary trailing margin,
                    // instead of as a gap in the middle of the row.
                    .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
                    .lifeCard()
                }
            }
        }
        .accessibilityValue("Category colour \(categoryColorHex(forCategory: visit.insightCategory))")
        .buttonStyle(.plain)
    }

    private var journeyDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            if visit.needsCategorisation {
                Text("Uncategorised location").font(.headline.weight(.semibold)).foregroundStyle(.primary)
                Text("Suspected: \(visit.inferredActivity)")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if visit.hasRoute {
                // A journey is described by how far it went. Its place name is only
                // ever "Walking workout", which says nothing.
                Text(visit.activity).font(.headline.weight(.semibold)).foregroundStyle(.primary)
                Text(formattedDistance(visit.routeDistance))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                // Place name leads, activity follows -- matching the Current
                // Activity card above, so the same "Home"/"At home" pairing
                // doesn't read backwards between the two.
                Text(visit.displayPlaceName).font(.headline.weight(.semibold)).foregroundStyle(.primary)
                Text(visit.activity).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(timeDescription).font(.subheadline).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var status: some View {
        if visit.needsCategorisation {
            Label(isCurrent ? "Live · Categorise" : "Categorise", systemImage: "flag.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.orange.opacity(0.1), in: Capsule())
        } else if isCurrent {
            Label("Live", systemImage: "circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Text(visit.confidenceLabel).font(.caption.weight(.semibold)).foregroundStyle(.green)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.green.opacity(0.1), in: Capsule())
        }
    }

    private var timeDescription: String {
        let start = dayQualifiedTime(visit.arrival)
        if isCurrent { return "Since \(start)" }
        let end = (visit.departure ?? .now).formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private var durationDescription: String { formattedDuration(visit.duration) }
}
