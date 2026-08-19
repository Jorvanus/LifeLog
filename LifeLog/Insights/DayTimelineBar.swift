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

    var isTravel: Bool {
        segment.category.caseInsensitiveCompare("Travel") == .orderedSame ||
            segment.category.caseInsensitiveCompare(CommuteDetection.categoryName) == .orderedSame
    }
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
    @State private var isShowingEntries = false

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
                            DayBarSegment(block: block,
                                          width: available * block.hours / totalHours,
                                          onSelect: onSelect)
                        }
                    }
                    if let nowFraction {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2)
                            .offset(x: proxy.size.width * nowFraction - 1)
                            .accessibilityHidden(true)
                    }
                    // Short periods have to remain visually proportional, which can
                    // make them only a few points wide. The whole bar opens a readable
                    // chronological list instead of demanding a tiny target.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isShowingEntries = true }
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 44)
            GeometryReader { proxy in
                let tickPositions = [0, 6, 12, 18].map {
                    proxy.size.width * CGFloat($0) / 24
                }
                let nowPosition = nowFraction.map { proxy.size.width * $0 }
                let nowSharesTick = nowPosition.map { position in
                    tickPositions.contains { abs($0 - position) < 34 }
                } ?? false
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(hourLabel(hour))
                        .font(.caption2).foregroundStyle(.secondary)
                        .position(x: proxy.size.width * CGFloat(hour) / 24, y: 8)
                }
                if let nowFraction {
                    Text("Now")
                        .font(.caption2.bold()).foregroundStyle(.primary)
                        // Keep the marker readable when it is close to a fixed
                        // six-hour tick (for example, 6:37pm beside 6pm).
                        .position(x: min(max(proxy.size.width * nowFraction, 14), proxy.size.width - 14),
                                  y: nowSharesTick ? 23 : 8)
                }
            }
            .frame(height: 30)
            DayTimelineLegend()
            Text("Tap the timeline to see its recorded periods.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isShowingEntries) {
            DayTimelineEntriesSheet(blocks: blocks, onSelect: onSelect)
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

/// A readable counterpart to the proportional day bar. It retains unlogged gaps so
/// the list explains the whole elapsed day, while each row remains a normal-sized
/// control that opens the same review destination as its timeline segment.
private struct DayTimelineEntriesSheet: View {
    let blocks: [DayBarBlock]
    let onSelect: (InsightSegment) -> Void
    @Environment(\.dismiss) private var dismiss

    private var pastBlocks: [DayBarBlock] { blocks.filter { !$0.isFuture } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(pastBlocks) { block in
                    Button {
                        dismiss()
                        onSelect(block.segment)
                    } label: {
                        DayTimelineEntryRow(block: block)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Timeline periods")
        }
        .presentationDetents([.medium, .large])
    }
}

private struct DayTimelineEntryRow: View {
    let block: DayBarBlock

    private var title: String {
        if block.segment.isUnlogged { return "Not logged" }
        if block.segment.isSleep { return "Sleep" }
        if block.isTravel { return "Travel" }
        return block.segment.activity
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(block.segment.isUnlogged ? Color.gray.opacity(0.45) : block.segment.color)
                .frame(width: 8, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text("\(block.start.formatted(date: .omitted, time: .shortened)) – \(block.end.formatted(date: .omitted, time: .shortened)) · \(formatHours(block.hours))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened)), \(formatHours(block.hours))")
        .accessibilityHint("Opens this period")
    }
}

/// Keeps the bar readable without making the legend another card. The adaptive
/// grid wraps at Dynamic Type sizes instead of shrinking labels into illegibility.
private struct DayTimelineLegend: View {
    private let items: [(String, String)] = [
        ("Recorded", "square.fill"),
        ("Future", "rectangle.slash.fill"),
        ("Unlogged", "circle.dotted"),
        ("Sleep", "bed.double.fill"),
        ("Travel", "car.fill")
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), alignment: .leading)],
                  alignment: .leading, spacing: 5) {
            ForEach(items, id: \.0) { title, symbol in
                Label(title, systemImage: symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline key: recorded, future, unlogged, sleep, and travel")
    }
}

/// A segment keeps the activity's established colour, then adds a texture or
/// edge treatment for states whose colour alone is ambiguous in a 24-hour bar.
private struct DayBarSegment: View {
    let block: DayBarBlock
    let width: CGFloat
    let onSelect: (InsightSegment) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor)
            if block.isFuture {
                DayBarHatch(color: .primary.opacity(0.24), spacing: 7)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if block.segment.isUnlogged {
                DayBarDots(color: .primary.opacity(0.36), spacing: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if !block.isFuture && block.segment.isSleep && width >= 24 {
                Image(systemName: "bed.double.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 1)
            } else if !block.isFuture && block.isTravel && width >= 24 {
                Image(systemName: "car.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 1)
            }
        }
        .frame(width: width)
        .overlay {
            if !block.isFuture && block.isTravel {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.85), lineWidth: 1)
            }
        }
        .onTapGesture {
            guard !block.isFuture else { return }
            onSelect(block.segment)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("day-bar-segment-\(block.id)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(block.isFuture ? [] : .isButton)
    }

    private var fillColor: Color {
        if block.isFuture { return Color.secondary.opacity(0.11) }
        if block.segment.isUnlogged { return Color.gray.opacity(0.28) }
        return block.segment.color
    }

    private var accessibilityLabel: String {
        if block.isFuture { return "Future time, \(formatHours(block.hours))" }
        if block.segment.isUnlogged { return "Unlogged time, \(formatHours(block.hours))" }
        if block.segment.isSleep { return "Sleep, \(formatHours(block.hours))" }
        if block.isTravel { return "Travel, \(formatHours(block.hours))" }
        return "\(block.segment.activity), \(formatHours(block.hours))"
    }
}

private struct DayBarHatch: View {
    let color: Color
    let spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: -size.height, through: size.width, by: spacing) {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct DayBarDots: View {
    let color: Color
    let spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            for y in stride(from: spacing / 2, through: size.height, by: spacing) {
                for x in stride(from: spacing / 2, through: size.width, by: spacing) {
                    let dot = Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    context.fill(dot, with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
