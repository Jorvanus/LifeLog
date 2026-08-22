import SwiftUI

/// Shown once, before any system permission dialog fires, so a first-time person
/// has LifeLog's own explanation before three separate iOS prompts arrive back to
/// back with nothing but Info.plist's generic strings. `RootView` gates this on
/// `RecordingObservation.startedAt()` being unset — the same "genuinely first
/// launch" signal already used to draw the unlogged-gap boundary — so an upgrade
/// or a restored backup never shows this again.
struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Welcome to LifeLog")
                        .font(.largeTitle.bold())
                    Text("A private, on-device timeline of your day — where you went, what you did, and how you slept. Nothing you record ever leaves this iPhone; there is no LifeLog server.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 22) {
                    OnboardingPermissionRow(
                        symbol: "location.fill",
                        title: "Location",
                        detail: "So LifeLog can notice when you arrive somewhere new and add it to your timeline automatically. You'll be asked for this first — background access, for when LifeLog isn't open, can be turned on afterward from Settings."
                    )
                    OnboardingPermissionRow(
                        symbol: "figure.walk",
                        title: "Motion & Fitness",
                        detail: "So walks, runs, cycling, and drives between places show up as their own timeline entries."
                    )
                    OnboardingPermissionRow(
                        symbol: "heart.fill",
                        title: "Apple Health",
                        detail: "So sleep, workouts, and related Health data can fill in your timeline. This access is read-only — LifeLog never writes to Health, and this data never leaves your phone."
                    )
                }

                Text("You'll see a few iPhone permission prompts next, one after another. Every one of these can be changed later from LifeLog's Settings tab.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .padding(.bottom, 60)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Continue", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.bar)
                .accessibilityIdentifier("onboarding-continue")
        }
    }
}

private struct OnboardingPermissionRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
