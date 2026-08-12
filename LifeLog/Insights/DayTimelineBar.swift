import SwiftUI

/// One block of the day bar: a slice of `segment` on one side or the other of
/// `now`. Most segments need only one — this only produces two when a single
/// segment (typically a trailing unlogged gap) straddles the current moment,
/// since `InsightsSnapshot.makeSegments` only adds `now` as a boundary when an
/// open visit forces it to.
private struct DayBarBlock: Identifiable {
    let id: Int
    let segment: InsightSegment
    let start: Date
    let end: Date
    let isFuture: Bool
    var hours: Double { end.timeIntervalSince(start) / 3600 }
}

/// The chronological 24-hour view of one day: every post-resolution segment
/// `InsightsSnapshot` already produces, laid out at its true position on a
/// fixed midnight-to-midnight scale rather than rescaled to whatever fraction
/// of the day has elapsed. Reuses the same segments the donut is built from —
/// see `InsightsView.daySegments` — so a block's width can never disagree
/// with what the donut or the day summary say about the same stretch of time.
struct DayTimelineBar: View {
    let segments: [InsightSegment]
    /// The full calendar day, uncapped — unlike `InsightsSnapshot.analysisInterval`,
    /// which stops at `now` for today. A day bar with no future half would have
    /// nothing to place a "now" marker in front of.
    let interval: DateInterval
    let now: Date
    let onSelect: (InsightSegment) -> Void

    private static let gap: CGFloat = 2

    /// Segments as drawn: any segment that straddles `now` is split into a past
    /// and a future half here, at render time only, so the underlying resolved
    /// segment list stays exactly what the donut/summary read.
    private var blocks: [DayBarBlock] {
        var result: [DayBarBlock] = []
        for segment in segments {
            if interval.contains(now), segment.start < now, segment.end > now {
                result.append(DayBarBlock(id: result.count, segment: segment, start: segment.start, end: now, isFuture: false))
                result.append(DayBarBlock(id: result.count, segment: segment, start: now, end: segment.end, isFuture: true))
            } else {
                result.append(DayBarBlock(id: result.count, segment: segment, start: segment.start, end: segment.end,
                                          isFuture: segment.start >= now && interval.contains(now)))
            }
        }
        return result
    }

    private var totalHours: Double { max(interval.duration / 3600, 0.01) }
    private var nowFraction: CGFloat? {
        guard interval.contains(now) else { return nil }
        return CGFloat(now.timeIntervalSince(interval.start) / interval.duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let blocks = self.blocks
                let gaps = Self.gap * CGFloat(max(blocks.count - 1, 0))
                let available = max(proxy.size.width - gaps, 1)
                ZStack(alignment: .leading) {
                    HStack(spacing: Self.gap) {
                        ForEach(blocks) { block in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(block.isFuture ? Color.secondary.opacity(0.08) : block.segment.color)
                                .frame(width: available * block.hours / totalHours)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard !block.isFuture else { return }
                                    onSelect(block.segment)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(block.isFuture
                                    ? "Later today"
                                    : "\(block.segment.activity), \(formatHours(block.hours))")
                                .accessibilityAddTraits(block.isFuture ? [] : .isButton)
                        }
                    }
                    if let nowFraction {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2)
                            .offset(x: proxy.size.width * nowFraction - 1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 34)
            GeometryReader { proxy in
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(hourLabel(hour))
                        .font(.caption2).foregroundStyle(.secondary)
                        .position(x: proxy.size.width * CGFloat(hour) / 24, y: 8)
                }
                if let nowFraction {
                    Text("Now")
                        .font(.caption2.bold()).foregroundStyle(.primary)
                        .position(x: min(max(proxy.size.width * nowFraction, 14), proxy.size.width - 14), y: 8)
                }
            }
            .frame(height: 16)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12am"
        case 12: "12pm"
        case let hour where hour < 12: "\(hour)am"
        default: "\(hour - 12)pm"
        }
    }
}
