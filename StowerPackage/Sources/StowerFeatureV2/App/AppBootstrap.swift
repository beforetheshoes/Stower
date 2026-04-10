import ComposableArchitecture
import Dependencies

public enum StowerAppBootstrap {
    @MainActor
    public static func makeStore() -> StoreOf<AppFeature> {
        do {
            try prepareDependencies {
                // Keep a delegate alive for the lifetime of the sync engine.
                // It is retained by SyncEngine, so we don't need extra storage in SwiftUI.
                try $0.bootstrapStowerDatabase()
            }
        } catch {
            assertionFailure("Failed to bootstrap database: \(error)")
        }

        return Store(initialState: AppFeature.State()) {
            AppFeature()
        }
    }
}
