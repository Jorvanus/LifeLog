import SwiftUI
import MapKit
import Charts

/// The day's ring, and the small map of where it was spent. Both are driven
/// entirely by an `InsightsSnapshot`; neither reads the store.
struct InsightsDonutChart: View {
    let activityData: ActivityDataService
    let segments: [InsightSegment]
    let loggedHours: Double
    let totalHours: Double
    let analysisInterval: DateInterval
    /// Called when the focused slice's centre detail is tapped again, so the
    /// parent can open that entry the same way the legend rows below do.
    let onSelectEntry: (TimeSlice) -> Void
    @State private var selectedAngle: Double?
    @State private var focusedSliceID: String?
    @State private var sleepSummary: SleepSummary?
    @State private var stepCount: Double?

    private var slices: [TimeSlice] {
        let grouped = Dictionary(grouping: segments) { segment in
            "\(segment.isUnlogged ? "gap" : "logged"):\(segment.category)"
        }
        return grouped.values.compactMap { items in
            guard let first = items.first else { return nil }
            return TimeSlice(
                name: first.category,
                hours: items.reduce(0) { $0 + $1.hours },
                color: first.color,
                symbol: first.symbol,
                isUnlogged: first.isUnlogged
            )
        }
        .filter { $0.hours > 0.01 }
        .sorted { $0.hours > $1.hours }
    }

    private var focusedSlice: TimeSlice? {
        guard let focusedSliceID else { return nil }
        return slices.first { $0.id == focusedSliceID }
    }

    private var focusedSegment: InsightSegment? {
        guard let focusedSlice else { return nil }
        return Self.representativeSegment(in: segments, matching: focusedSlice.name,
                                          isUnlogged: focusedSlice.isUnlogged)
    }

    /// The largest segment in a category, not the earliest one. A category
    /// interrupted partway through the day (Home, split by Sleep) has several
    /// segments; the wedge is sized by all of them together, but the In/Out readout
    /// can only show one, and picking the first picked whichever happened earliest
    /// in the day — sometimes a sliver of a few minutes with no relation to what the
    /// wedge's size or "View entry" actually represents.
    nonisolated static func representativeSegment(in segments: [InsightSegment], matching category: String,
                                                   isUnlogged: Bool) -> InsightSegment? {
        segments
            .filter { $0.category == category && $0.isUnlogged == isUnlogged }
            .max { $0.hours < $1.hours }
    }

    /// Below this a wedge is too narrow to hold anything legible, and its icon would
    /// spill over its neighbours.
    private static let iconLabelShare = 0.035
    /// And below this there is room for the icon but not the duration under it.
    private static let fullLabelShare = 0.08

    var body: some View {
        ZStack {
            Chart(slices) { slice in
                let selected = focusedSliceID == slice.id
                let hasSelection = focusedSlice != nil
                SectorMark(
                    angle: .value("Hours", slice.hours),
                    innerRadius: .ratio(0.56),
                    outerRadius: .ratio(selected ? 1 : 0.95),
                    angularInset: 2
                )
                .cornerRadius(6)
                .foregroundStyle(slice.color.opacity(hasSelection && !selected ? 0.2 : 1))
                .annotation(position: .overlay) {
                    // The legend under the ring is gone, so a wedge with no label is now
                    // an unidentifiable colour rather than a colour with a key beside it.
                    // Anything worth a wedge gets its icon; only the wider ones have room
                    // for the duration underneath as well.
                    let share = slice.hours / max(totalHours, 1)
                    if !hasSelection && share > Self.iconLabelShare {
                        VStack(spacing: 2) {
                            Image(systemName: slice.symbol)
                            if share > Self.fullLabelShare {
                                Text(formatHours(slice.hours)).font(.caption.bold())
                            }
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
            .chartLegend(.hidden)
            // Keep the binding for the selected data value, but forward each tap through
            // ChartProxy, which handles the polar-to-data-angle conversion.
            .chartAngleSelection(value: $selectedAngle)
            .chartOverlay { proxy in
                GeometryReader { _ in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        // A tap, not a zero-distance drag. The drag this replaces claimed
                        // every gesture beginning anywhere on the chart, so the scroll view
                        // never saw them: the donut was a dead zone the height of the card,
                        // and the page could only be scrolled around it. A tap recognises
                        // the same taps and lets a drag pass through untouched.
                        .onTapGesture { location in
                            let angle = proxy.angle(at: location)
                            // ChartProxy returns the polar angle in screen coordinates.
                            // Convert it back through the chart's data scale before
                            // comparing it with cumulative segment hours; raw degrees
                            // select the wrong slice.
                            guard let angleValue: Double = proxy.value(atAngle: angle, as: Double.self),
                                  let slice = slice(at: angleValue) else { return }
                            if focusedSliceID == slice.id {
                                // A second tap on the focused slice restores the neutral
                                // donut and brings every slice back to full opacity.
                                focusedSliceID = nil
                                selectedAngle = nil
                            } else {
                                focusedSliceID = slice.id
                                selectedAngle = angleValue
                            }
                        }
                }
            }
            .onChange(of: selectedAngle) { _, angle in
                guard let angle, let slice = slice(at: angle) else { return }
                // Apply immediately so the previous focus cannot flash during a new tap.
                focusedSliceID = slice.id
            }
            .onChange(of: segments.map(\.id)) { _, _ in
                if let focusedSliceID, !slices.contains(where: { $0.id == focusedSliceID }) {
                    self.focusedSliceID = nil
                    selectedAngle = nil
                }
            }
            .accessibilityHint("Highlight this entry and show its check-in, check-out, and duration. Tap the centre card again to open it.")
            .task(id: sleepSummaryKey) {
                sleepSummary = nil
                guard let segment = focusedSegment, segment.isSleep else { return }
                sleepSummary = await activityData.sleepSummary(
                    for: DateInterval(start: segment.start, end: segment.end)
                )
            }

            if let focusedSegment, let focusedSlice {
                // The centre card sits over the donut's empty hole, not over any
                // wedge, so re-enabling hit testing here can't steal a wedge tap:
                // wedge taps still reach the chartOverlay gesture below. Tapping
                // the card itself opens the underlying visit(s), matching the
                // legend rows' tap-to-navigate behaviour.
                Button {
                    onSelectEntry(focusedSlice)
                } label: {
                    if focusedSegment.isSleep {
                        sleepCenter(for: focusedSegment)
                    } else {
                        focusedCenter(for: focusedSegment)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this entry to review or edit")
            } else {
                VStack(spacing: 2) {
                    if let stepCount {
                        Text(formatSteps(stepCount)).font(.title.bold()).monospacedDigit()
                        Text("steps").font(.subheadline).foregroundStyle(.secondary)
                        Text("Apple Health").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text("—").font(.title.bold()).monospacedDigit()
                        Text("steps").font(.subheadline).foregroundStyle(.secondary)
                        Text("No step data").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                // Bounded to the widest line that fits the hole. The ring's inner radius
                // is a ratio of its size, so a square inside that circle is narrower
                // still. Health setup deliberately lives in the readable card above it.
                .frame(maxWidth: centreWidth)
                .multilineTextAlignment(.center)
                .allowsHitTesting(false)
            }
        }
        // Square, sized from the width it is given rather than a fixed height, so the
        // ring fills the card the way the rest of the screen does. It was 330pt tall on
        // every device, which left a band of empty card either side of it on a 6.9"
        // screen. A bigger ring also means a bigger hole, which is the one thing the
        // centre text has always been short of.
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        // The ring is fixed geometry: the hole is a ratio of its radius, so text sitting
        // inside cannot grow without limit. At the largest accessibility sizes it was
        // rendering several times the width of the hole — "1h 10m" lay across the
        // segments, "steps" ran under the tab bar, and labels drew over one another
        // into an unreadable smear.
        //
        // Only what is inside the ring is capped. Every other word on the page still
        // scales the whole way; this is the one place the container genuinely cannot
        // follow the text, and legible-but-capped beats overlapping.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityIdentifier("insights-donut-chart")
        .task(id: stepCountKey) {
            // Let the chart render before asking HealthKit for samples. This keeps
            // navigation responsive on devices with a large Health history.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            stepCount = await activityData.stepCount(for: analysisInterval)
        }
    }

    /// The usable width inside the ring. `chartHeight` × the 0.56 inner-radius ratio
    /// gives a hole roughly 185pt across; text has to fit a square inside that circle,
    /// not the circle itself, so this is deliberately narrower.
    /// The hole is 56% of the ring, and the largest square inside a circle is about 70%
    /// of its diameter. On a 6.9" screen the ring is roughly 350pt across, so the usable
    /// box is around 140pt — kept a little under that, because text that just fits is
    /// text that overlaps at the next Dynamic Type size.
    private var centreWidth: CGFloat { 170 }

    private var stepCountKey: String {
        "\(analysisInterval.start.timeIntervalSinceReferenceDate)-\(analysisInterval.end.timeIntervalSinceReferenceDate)"
    }

    private func slice(at angle: Double) -> TimeSlice? {
        guard angle.isFinite, angle >= 0 else { return nil }
        var upperBound = 0.0
        for slice in slices {
            upperBound += slice.hours
            if angle <= upperBound { return slice }
        }
        return slices.last
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
                Text("Not an Apple Health score")
                    .font(.caption2).foregroundStyle(.secondary)
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
            entryAffordance(hasVisit: true)
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
            if let visit = segment.visit {
                Text(visit.confidenceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(visit.recognitionConfidence == "confirmed" ? .green : .secondary)
                Text("Evidence: \(evidenceText(for: visit))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else {
                Text("No inferred activity")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 2)
            Text("In  \(timeLabel(segment.start))")
            Text("Out  \(segment.isLive ? "Now" : timeLabel(segment.end))")
            Text(formatHours(segment.end.timeIntervalSince(segment.start) / 3600))
                .font(.subheadline.bold().monospacedDigit()).padding(.top, 2)
            entryAffordance(hasVisit: segment.visit != nil)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.primary)
        .frame(width: 176)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(segment.activity), \(segment.placeName ?? ""), \(segment.visit?.confidenceLabel ?? "not inferred"), evidence \(segment.visit.map(evidenceText) ?? "none"), in \(timeLabel(segment.start)), out \(segment.isLive ? "now" : timeLabel(segment.end)), duration \(formatHours(segment.end.timeIntervalSince(segment.start) / 3600))")
    }

    /// Small tappable-looking cue so the centre card reads as a button, not just
    /// a readout, once a wedge is focused.
    private func entryAffordance(hasVisit: Bool) -> some View {
        HStack(spacing: 3) {
            Text(hasVisit ? "View entry" : "Add visit")
            Image(systemName: "chevron.right")
        }
        .font(.caption2.bold())
        .foregroundStyle(.blue)
        .padding(.top, 3)
    }

    private func evidenceText(for visit: Visit) -> String {
        var evidence = visit.inferenceEvidence
        let key = visit.placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty, key != "identifying…", key != "unknown place" {
            let recurrence = segments.compactMap(\.visit).filter { candidate in
                candidate.id != visit.id &&
                    candidate.placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
            }.count
            if recurrence > 0 { evidence.append("Recurring place") }
        }
        return evidence.isEmpty ? "No evidence recorded" : evidence.joined(separator: " · ")
    }

    private func timeLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

struct InsightsPlacesMap: View {
    let places: [PlaceTotal]
    let region: MKCoordinateRegion
    let onSelectPlace: (PlaceTotal) -> Void
    @State private var selectedName: String?

    var body: some View {
        Map(initialPosition: .region(region), selection: $selectedName) {
            ForEach(places) { place in
                // Always-visible labels overlap as soon as nearby places share a map.
                // Native markers retain the name in their tap callout without covering
                // the location and automatically use the platform's map interaction.
                Marker(place.name, coordinate: place.coordinate)
                    .tint(.blue)
                    .tag(place.name)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onChange(of: selectedName) { _, name in
            guard let name, let place = places.first(where: { $0.name == name }) else { return }
            onSelectPlace(place)
        }
    }
}
