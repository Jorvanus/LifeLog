import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var recorder = LocationRecorder()
    @State private var activityData = ActivityDataService()
    @State private var selectedTab = ProcessInfo.processInfo.arguments.contains("-showInsights") ? 1 : 0

    var body: some View {
        TabView(selection: $selectedTab) {
            TimelineView().tabItem { Label("Timeline", systemImage: "clock") }.tag(0)
            TrendsView().tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }.tag(1)
            MapView().tabItem { Label("Map", systemImage: "map") }.tag(2)
            SettingsView(recorder: recorder, activityData: activityData).tabItem { Label("Settings", systemImage: "gear") }.tag(3)
        }
        .tint(.blue)
        .task {
            recorder.connect(context)
            activityData.connect(context)
        }
    }
}
