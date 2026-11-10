import ComposableArchitecture
import Dependencies

public enum StowerAppBootstrap {
    @MainActor
    public static func makeStore() -> StoreOf<AppFeature> {
        var state = AppFeature.State()
        do {
            try prepareDependencies {
                // Keep a delegate alive for the lifetime of the sync engine.
                // It is retained by SyncEngine, so we don't need extra storage in SwiftUI.
                try $0.bootstrapStowerDatabase()
            }
        } catch {
            // A release build used to carry on silently with no database:
            // an empty library and saves that went nowhere. Say so instead.
            reportIssue(error, "Failed to bootstrap database")
            state.databaseUnavailableMessage =
                "Stower could not open its library: \(error.localizedDescription)"
        }

        return Store(initialState: state) {
            AppFeature()
        }
    }
}
