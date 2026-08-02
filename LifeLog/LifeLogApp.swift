import SwiftUI
import SwiftData

@main
struct LifeLogApp: App {
    private let modelContainer: ModelContainer?

    init() {
        // Keep the SwiftData schema limited to the timeline models. User-editable
        // activities live in a versioned UserDefaults payload, avoiding a risky
        // model migration for existing protected timeline stores.
        let schema = Schema([Visit.self, SavedPlace.self, VisitCorrection.self, DiagnosticEvent.self])
        let configuration = ModelConfiguration(
            "LifeLog",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        modelContainer = try? ModelContainer(for: schema, configurations: [configuration])
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                RootView(modelContainer: modelContainer).modelContainer(modelContainer)
            } else {
                ContentUnavailableView(
                    "Timeline unavailable",
                    systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text("LifeLog couldn’t open its protected on-device timeline. Restart the iPhone and try again.")
                )
            }
        }
    }
}
