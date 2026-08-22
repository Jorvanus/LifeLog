import SwiftUI

/// Compact entry point for data LifeLog already has permission to read. It stays
/// observational: values are attributed to Apple Health and never framed as a
/// diagnosis, target, or medical assessment.
struct HealthOverviewCard: View {
    let summary: HealthInsightsSummary
    let previous: HealthInsightsSummary?
    let interval: DateInterval
    let periodTitle: String
    let activityData: ActivityDataService

    var body: some View {
        NavigationLink {
            HealthOverviewDetailView(summary: summary, previous: previous, interval: interval,
                                     periodTitle: periodTitle, activityData: activityData)
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HealthOverviewCardHeader(periodTitle: periodTitle)
                HealthOverviewMetricGrid(metrics: healthOverviewMetrics(from: summary, maximumCount: 4))
                if let sleep = summary.sleep, sleep.totalSleep > 0 {
                    HealthOverviewSleepLine(sleep: sleep)
                }
                if let change = HealthOverviewChange.make(current: summary, previous: previous) {
                    Text(change)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .lifeCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("insights-health-overview")
        .accessibilityLabel("Apple Health overview for \(periodTitle)")
        .accessibilityHint("Opens Health details for this period")
    }
}

private struct HealthOverviewCardHeader: View {
    let periodTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label("Health overview", systemImage: "heart.text.square.fill")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            Text("Apple Health · \(periodTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct HealthOverviewDetailView: View {
    let summary: HealthInsightsSummary
    let previous: HealthInsightsSummary?
    let interval: DateInterval
    let periodTitle: String
    let activityData: ActivityDataService

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HealthOverviewHeader(periodTitle: periodTitle, source: summary.source,
                                     lastImport: summary.lastSuccessfulImport)
                HealthOverviewMetricsSection(summary: summary, previous: previous)
                if let sleep = summary.sleep, sleep.totalSleep > 0 {
                    HealthSleepDetailSection(sleep: sleep, interval: interval,
                                             activityData: activityData)
                }
                if !summary.workouts.isEmpty {
                    HealthWorkoutsSection(workouts: summary.workouts)
                }
                if summary.restingHeartRateBPM != nil || summary.walkingHeartRateBPM != nil ||
                    summary.respiratoryRate != nil {
                    HealthSignalsSection(summary: summary)
                }
                NavigationLink {
                    HealthTrendsView(activityData: activityData, interval: interval,
                                     periodTitle: periodTitle)
                } label: {
                    Label("Explore heart and breathing trends", systemImage: "chart.xyaxis.line")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("health-trends-link")
            }
            .padding(18)
        }
        .background(Color.lifeBackground.ignoresSafeArea())
        .navigationTitle("Health details")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("health-overview-detail")
    }
}

private struct HealthOverviewHeader: View {
    let periodTitle: String
    let source: String
    let lastImport: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Health overview", systemImage: "heart.text.square.fill")
                .font(.title2.bold())
            Text("Recorded by \(source) for \(periodTitle.lowercased()). These values describe what was recorded; they are not medical interpretation.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let lastImport {
                Text("Last successful import: \(lastImport.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HealthOverviewMetricsSection: View {
    let summary: HealthInsightsSummary
    let previous: HealthInsightsSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Activity and movement").font(.headline)
            HealthOverviewMetricGrid(metrics: healthOverviewMetrics(from: summary))
            if let change = HealthOverviewChange.make(current: summary, previous: previous) {
                Text(change).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("health-overview-metrics")
    }
}

private struct HealthOverviewMetricGrid: View {
    let metrics: [HealthMetric]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 16, alignment: .leading)],
                  alignment: .leading, spacing: 14) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 4) {
                    Label(metric.title, systemImage: metric.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(metric.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(metric.title): \(metric.value), Apple Health")
            }
        }
    }
}

private struct HealthOverviewSleepLine: View {
    let sleep: SleepSummary

    var body: some View {
        // Matches `HealthOverviewMetricGrid`'s two equal-width leading-aligned
        // columns (same 16pt gap) so this row's duration lines up under
        // whichever metric landed in the grid's second column, instead of
        // floating at the card's trailing edge.
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "bed.double.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sleep")
                        .font(.subheadline.weight(.semibold))
                    Text("Apple Health")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(healthDuration(sleep.totalSleep))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
        .overlay(alignment: .top) { Divider().offset(y: -8) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep: \(healthDuration(sleep.totalSleep)), Apple Health")
    }
}

private struct HealthSleepDetailSection: View {
    let sleep: SleepSummary
    let interval: DateInterval
    let activityData: ActivityDataService
    @State private var baseline: SleepPatternBaseline?
    @State private var exerciseComparison: SleepExerciseComparison?

    private var baselineStart: Date { Calendar.current.startOfDay(for: interval.start) }
    private var showsPersonalPattern: Bool { interval.duration <= 36 * 60 * 60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sleep from Apple Health").font(.headline)
            HealthDetailRow(title: "Duration", value: healthDuration(sleep.totalSleep), icon: "bed.double.fill")
            if sleep.timeInBed > 0 {
                HealthDetailRow(title: "Time in bed", value: healthDuration(sleep.timeInBed), icon: "bed.double")
            }
            if sleep.interruptions > 0 {
                HealthDetailRow(title: "Interruptions", value: "\(sleep.interruptions)", icon: "moon.zzz.fill")
            }
            if sleep.rem + sleep.core + sleep.deep > 0 {
                HealthDetailRow(title: "Stages recorded", value: stageSummary(sleep), icon: "circle.hexagongrid.fill")
            }
            Text("LifeLog sleep estimate: \(sleep.estimatedScore)/100. This is LifeLog’s estimate from recorded duration, stages, and interruptions—not an Apple Health or Apple Watch score.")
                .font(.footnote).foregroundStyle(.secondary)
            if showsPersonalPattern {
                HealthSleepConsistencyLine(sleep: sleep, baseline: baseline)
            }
            if let exerciseComparison {
                SleepExerciseComparisonLine(comparison: exerciseComparison)
            }
        }
        .padding(20).lifeCard()
        .task(id: showsPersonalPattern ? baselineStart : .distantPast) {
            baseline = showsPersonalPattern
                ? await activityData.sleepPatternBaseline(before: baselineStart)
                : nil
        }
        // Not gated by `showsPersonalPattern`: this compares two groups of
        // nights against each other, not the viewed period's own single
        // session against a rolling average, so it means the same thing
        // whichever period brought the person to this screen.
        .task(id: baselineStart) {
            exerciseComparison = await activityData.sleepExerciseComparison(before: baselineStart)
        }
        .accessibilityIdentifier("health-sleep-detail")
    }
}

private struct HealthSleepConsistencyLine: View {
    let sleep: SleepSummary
    let baseline: SleepPatternBaseline?

    var body: some View {
        Group {
            if let baseline {
                let durationDelta = sleep.totalSleep - baseline.averageDuration
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compared with your recent \(baseline.nights) nights")
                        .font(.subheadline.weight(.semibold))
                    Text("Duration \(healthSignedDuration(durationDelta)) from your average.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let start = sleep.sleepStart {
                        Text("Sleep started \(baseline.timingDifference(from: start)) min from your usual recorded timing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Sleep timing was not available in this session.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct SleepExerciseComparisonLine: View {
    let comparison: SleepExerciseComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sleep on days you exercised").font(.subheadline.weight(.semibold))
            Text("\(healthDuration(comparison.averageSleepOnExerciseDays)) average over \(comparison.exerciseNights) nights with a workout, vs. \(healthDuration(comparison.averageSleepOnRestDays)) over \(comparison.restNights) nights without.")
                .font(.footnote).foregroundStyle(.secondary)
            // A workout and a good night's sleep sharing a cause -- a rest
            // day, say -- explains a pattern here just as well as either one
            // explaining the other, so this never claims more than what was
            // recorded side by side.
            Text("An observation, not a recommendation — a rest day could explain both just as easily as one explaining the other.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityIdentifier("health-sleep-exercise-comparison")
    }
}

private struct HealthWorkoutsSection: View {
    let workouts: [HealthInsightsSummary.Workout]

    private var anyRecovered: Bool { workouts.contains { $0.heartRateRecoveryBPM != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workouts from Apple Health").font(.headline)
            ForEach(workouts.prefix(8)) { workout in
                HealthDetailRow(title: workout.type,
                                value: "\(healthDuration(workout.duration))\(workout.distanceMeters.map { " · \(healthDistance($0))" } ?? "")",
                                icon: "figure.run.circle.fill",
                                detail: workout.heartRateRecoveryBPM.map { "Recovered \(Int($0.rounded())) bpm in the first minute" })
            }
            // Only worth explaining the absence when it's total -- if some
            // workouts show a recovery reading and others don't, the pattern
            // (only Watch-tracked, supported types get one) speaks for itself.
            if !anyRecovered {
                Text("Heart-rate recovery needs a supported workout tracked on Apple Watch.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("health-workouts-detail")
    }
}

private struct HealthSignalsSection: View {
    let summary: HealthInsightsSummary

    /// A count this low means the "average" below is really just that many
    /// individual readings averaged together -- worth saying, so one reading
    /// early in a multi-day period doesn't read as a settled trend.
    private static let lowSampleCountFloor = 2

    private func readingCountLabel(_ count: Int) -> String? {
        guard count > 0, count <= Self.lowSampleCountFloor else { return nil }
        return count == 1 ? "1 reading" : "\(count) readings"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heart and breathing signals").font(.headline)
            Text("Apple Health averages for this period. They are observations, not medical interpretation.")
                .font(.footnote).foregroundStyle(.secondary)
            if let value = summary.restingHeartRateBPM {
                HealthDetailRow(title: "Resting heart rate", value: "\(Int(value.rounded())) bpm", icon: "heart.fill",
                                detail: readingCountLabel(summary.restingHeartRateSampleCount))
            }
            if let value = summary.walkingHeartRateBPM {
                HealthDetailRow(title: "Walking heart rate", value: "\(Int(value.rounded())) bpm", icon: "figure.walk",
                                detail: readingCountLabel(summary.walkingHeartRateSampleCount))
            }
            if let value = summary.respiratoryRate {
                HealthDetailRow(title: "Respiratory rate", value: "\(Int(value.rounded())) breaths/min", icon: "wind",
                                detail: readingCountLabel(summary.respiratoryRateSampleCount))
            }
        }
        .padding(20).lifeCard()
        .accessibilityIdentifier("health-signals-detail")
    }
}

private struct HealthDetailRow: View {
    let title: String
    let value: String
    let icon: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.subheadline.bold()).monospacedDigit().multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.map { "\(title): \(value), from \($0), Apple Health" } ?? "\(title): \(value), Apple Health")
    }
}

private struct HealthMetric: Identifiable {
    let id: String
    let title: String
    let value: String
    let icon: String
}

private func healthOverviewMetrics(from summary: HealthInsightsSummary,
                                   maximumCount: Int? = nil) -> [HealthMetric] {
    let metrics = [
        summary.steps.map { HealthMetric(id: "steps", title: "Steps", value: Int($0.rounded()).formatted(), icon: "shoeprints.fill") },
        summary.walkingRunningMeters.map { HealthMetric(id: "distance", title: "Walk + run", value: healthDistance($0), icon: "figure.walk") },
        summary.exerciseMinutes.map { HealthMetric(id: "exercise", title: "Exercise", value: "\(Int($0.rounded())) min", icon: "figure.run") },
        summary.workoutCount > 0 ? HealthMetric(id: "workouts", title: "Workouts", value: "\(summary.workoutCount) · \(Int(summary.workoutMinutes.rounded())) min", icon: "figure.run.circle.fill") : nil,
        summary.activeEnergyKilocalories.map { HealthMetric(id: "energy", title: "Active energy", value: "\(Int($0.rounded())) kcal", icon: "flame.fill") },
        summary.standHours.map { HealthMetric(id: "stand", title: "Stand", value: "\(Int($0.rounded())) hr", icon: "figure.stand") }
    ].compactMap { $0 }

    guard let maximumCount else { return metrics }
    return Array(metrics.prefix(maximumCount))
}

private enum HealthOverviewChange {
    static func make(current: HealthInsightsSummary, previous: HealthInsightsSummary?) -> String? {
        guard let previous else { return nil }
        if let change = HealthInsightsSummary.meaningfulChange(current: current.steps, previous: previous.steps, minimum: 1_000) {
            return "Steps were \(healthSignedInteger(change)) compared with the previous period."
        }
        if let change = HealthInsightsSummary.meaningfulChange(current: current.exerciseMinutes, previous: previous.exerciseMinutes, minimum: 20) {
            return "Exercise was \(healthSignedInteger(change)) min compared with the previous period."
        }
        return nil
    }
}

private func healthDistance(_ meters: Double) -> String {
    let kilometres = meters / 1_000
    return kilometres >= 1 ? "\(kilometres.formatted(.number.precision(.fractionLength(1)))) km" : "\(Int(meters.rounded())) m"
}

private func healthDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = Int((interval / 60).rounded())
    return totalMinutes >= 60 ? "\(totalMinutes / 60)h \(totalMinutes % 60)m" : "\(totalMinutes)m"
}

private func healthSignedDuration(_ interval: TimeInterval) -> String {
    let sign = interval >= 0 ? "+" : "−"
    return sign + healthDuration(abs(interval))
}

private func healthSignedInteger(_ value: Double) -> String {
    let sign = value >= 0 ? "+" : "−"
    return sign + Int(abs(value).rounded()).formatted()
}

private func stageSummary(_ sleep: SleepSummary) -> String {
    [
        sleep.rem > 0 ? "REM \(healthDuration(sleep.rem))" : nil,
        sleep.core > 0 ? "Core \(healthDuration(sleep.core))" : nil,
        sleep.deep > 0 ? "Deep \(healthDuration(sleep.deep))" : nil
    ].compactMap { $0 }.joined(separator: " · ")
}
