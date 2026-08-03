import SwiftUI
import SwiftData

@main
struct LifeLogApp: App {
    @State private var modelContainer: ModelContainer?
    @State private var storeOpenError: StoreOpenError?
    private let storeConfiguration: ModelConfiguration

    init() {
        // Keep the SwiftData schema limited to the timeline models. User-editable
        // activities live in a versioned UserDefaults payload, avoiding a risky
        // model migration for existing protected timeline stores.
        let schema = Schema(versionedSchema: LifeLogSchemaV1.self)
        storeConfiguration = ModelConfiguration(
            "LifeLog",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        do {
            _modelContainer = State(initialValue: try Self.openContainer(configuration: storeConfiguration, schema: schema))
            _storeOpenError = State(initialValue: nil)
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
            }
        }
    }

    private static func openContainer(configuration: ModelConfiguration, schema: Schema) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: LifeLogMigrationPlan.self,
            configurations: [configuration]
        )
    }

    private func retryStoreOpening() {
        do {
            let schema = Schema(versionedSchema: LifeLogSchemaV1.self)
            modelContainer = try Self.openContainer(configuration: storeConfiguration, schema: schema)
            storeOpenError = nil
        } catch {
            storeOpenError = StoreOpenError(error: error, storeURL: storeConfiguration.url)
        }
    }
}
