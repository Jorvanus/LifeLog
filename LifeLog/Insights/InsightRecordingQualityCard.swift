import SwiftUI

/// The recording-quality summary: how much of the selected period has an actual
/// record behind it, the gaps and provisional rows making up the rest, and which
/// individual days fell below a useful coverage bar. Placed ahead of Week/Month's
/// own decorative charts because it is the most actionable use of the archive --
/// it distinguishes "nothing happened" from "LifeLog has no evidence" -- and every
/// row here already has a correction path: gaps open Add Visit, provisional rows
/// open the existing editor.
struct InsightRecordingQualityCard: View {
    let quality: InsightsRecordingQuality.Presentation
    let periodTitle: String
    let onOpenGaps: () -> Void
    let onOpenProvisional: () -> Void
    let onOpenDay: (Date) -> Void

    private var coveragePercent: Int { Int((quality.coverage * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording quality").font(.headline)
                Text("\(coveragePercent)% of \(periodTitle.lowercased()) has a record. The rest is a gap LifeLog has no evidence for, not a quiet day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)

            HStack(spacing: 10) {
                statTile(title: "Logged", value: formatHours(quality.loggedHours), icon: "checkmark.circle")
                statTile(title: "Total gaps", value: formatHours(quality.totalGapHours), icon: "clock.badge.questionmark")
                if let longestGap = quality.longestGap {
                    statTile(title: "Longest gap", value: formatHours(longestGap.hours), icon: "hourglass")
                }
            }

            if quality.gapCount > 0 {
                actionRow(icon: "clock.badge.questionmark", tint: .orange, title: "Unlogged gaps",
                         subtitle: "\(quality.gapCount) gap\(quality.gapCount == 1 ? "" : "s") · \(formatHours(quality.totalGapHours))",
                         action: onOpenGaps, identifier: "recording-quality-gaps")
            }

            if !quality.provisionalRows.isEmpty {
                actionRow(icon: "questionmark.circle", tint: .yellow, title: "Provisional rows",
                         subtitle: "\(quality.provisionalRows.count) not yet confirmed",
                         action: onOpenProvisional, identifier: "recording-quality-provisional")
            }

            if !quality.daysBelowThreshold.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Days below \(Int((quality.threshold * 100).rounded()))% coverage")
                        .font(.subheadline.weight(.semibold))
                    // Worst days first, capped: a mostly-unlogged period can flag
                    // dozens of days, and this card stays a summary, not the full
                    // list -- see `InsightsRecordingQuality.make`'s own sort.
                    ForEach(quality.daysBelowThreshold.prefix(Self.maxDisplayedDays)) { day in
                        Button { onOpenDay(day.date) } label: {
                            HStack {
                                Text(day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int((day.coverage * 100).rounded()))%")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.orange)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("recording-quality-low-day")
                        .accessibilityLabel("\(day.date.formatted(date: .complete, time: .omitted)), \(Int((day.coverage * 100).rounded()))% coverage")
                    }
                    if quality.daysBelowThreshold.count > Self.maxDisplayedDays {
                        Text("+\(quality.daysBelowThreshold.count - Self.maxDisplayedDays) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .lifeCard()
        .accessibilityIdentifier("insight-recording-quality-card")
    }

    private static let maxDisplayedDays = 5

    private func statTile(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold().monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func actionRow(icon: String, tint: Color, title: String, subtitle: String,
                           action: @escaping () -> Void, identifier: String) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title): \(subtitle)")
    }
}
