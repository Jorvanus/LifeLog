import SwiftUI

/// The step-by-step breakdown of one commute: the moving stretches, and any brief
/// real stop absorbed along the way (see `CommuteDetection.waypointTolerance`). A
/// commute has no backing `Visit` of its own — this reads straight from the `Commute`
/// the donut slice was built from, the same way `InsightSliceEditor` reads `SliceRow`.
struct CommuteDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let commute: Commute

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "car.fill")
                            .font(.title2.bold()).foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(insightColor(for: CommuteDetection.categoryName).gradient, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commute.direction.label).font(.title3.bold())
                            Text(formatHours(commute.duration / 3600)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(commute.direction.label), \(formatHours(commute.duration / 3600))")
                }
                ForEach(Array(commute.legs.enumerated()), id: \.element.id) { index, leg in
                    Section("Step \(index + 1)") {
                        legRow(leg)
                    }
                }
            }
            .navigationTitle(commute.direction.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func legRow(_ leg: Commute.Leg) -> some View {
        let (title, context) = legLabel(leg.kind)
        return HStack(spacing: 12) {
            ActivityIcon(activity: context, context: context, color: activityColor(context), size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(legTime(leg)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatHours(leg.duration / 3600))
                .font(.caption.bold().monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(legTime(leg)), \(formatHours(leg.duration / 3600))")
    }

    private func legLabel(_ kind: Commute.Leg.Kind) -> (title: String, context: String) {
        switch kind {
        case .transport: ("Transport", "Transport")
        case .stop(let placeName, let activityLabel): (placeName, activityLabel)
        }
    }

    private func legTime(_ leg: Commute.Leg) -> String {
        "\(leg.start.formatted(date: .omitted, time: .shortened))–\(leg.end.formatted(date: .omitted, time: .shortened))"
    }
}
