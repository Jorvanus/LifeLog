import SwiftUI
import SwiftData

@main
struct LifeLogApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var modelContainer: ModelContainer?
    @State private var storeOpenError: StoreOpenError?
    @State private var hasRetriedWhenActive = false
    private let storeConfiguration: ModelConfiguration

    init() {
        // Keep the SwiftData schema limited to the timeline models. User-editable
        // activities live in a versioned UserDefaults payload, avoiding a risky
        // model migration for existing protected timeline stores.
        let schema = Schema(versionedSchema: LifeLogSchemaV8.self)
        storeConfiguration = ModelConfiguration(
            "LifeLog",
            schema: schema,
            isStoredInMemoryOnly: ProcessInfo.processInfo.arguments.contains(UITestSeedData.launchArgument),
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        do {
            _modelContainer = State(initialValue: try Self.openContainer(configuration: storeConfiguration, schema: schema))
            _storeOpenError = State(initialValue: nil)
            if ProcessInfo.processInfo.arguments.contains(UITestSeedData.launchArgument), let container = _modelContainer.wrappedValue {
                try UITestSeedData.install(in: container)
            }
        } catch {
            _modelContainer = State(initialValue: nil)
            _storeOpenError = State(initialValue: StoreOpenError(error: error, storeURL: storeConfiguration.url))
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                RootView(modelContainer: modelContainer).modelContainer(modelContainer)
            } else {
                StoreRecoveryView(
                    failure: storeOpenError,
                    retry: retryStoreOpening
                )
                .task {
                    // If startup happened while locked, the view becomes visible
                    // only once the owner is back in the foreground. Try once
                    // without requiring an extra tap.
                    guard !hasRetriedWhenActive else { return }
                    hasRetriedWhenActive = true
                    retryStoreOpening()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // A background location launch may occur while the store is locked.
            // Retry once when the owner actively opens LifeLog instead of leaving
            // an otherwise healthy store on the recovery screen.
            guard phase == .active, modelContainer == nil, !hasRetriedWhenActive else { return }
            hasRetriedWhenActive = true
            retryStoreOpening()
        }
    }

    private static func openContainer(configuration: ModelConfiguration, schema: Schema) throws -> ModelContainer {
        let container = try ModelContainer(
            for: schema,
            migrationPlan: LifeLogMigrationPlan.self,
            configurations: [configuration]
        )
        StoreProtection.prepareForBackgroundAccess(storeURL: configuration.url)
        // A background callback may have been persisted just before termination.
        // Resolve before any screen reads the store so relaunch cannot resurrect an
        // older open stay or an overlap that Timeline would need to hide.
        let context = ModelContext(container)
        _ = try ActivityLocationPolicy.resolveAfterLocationMutation(context: context, reason: "relaunch recovery")
        try context.save()
        return container
    }

    private func retryStoreOpening() {
        do {
            let schema = Schema(versionedSchema: LifeLogSchemaV8.self)
            modelContainer = try Self.openContainer(configuration: storeConfiguration, schema: schema)
            storeOpenError = nil
        } catch {
            storeOpenError = StoreOpenError(error: error, storeURL: storeConfiguration.url)
        }
    }
}
