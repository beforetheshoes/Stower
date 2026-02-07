import ComposableArchitecture
import Dependencies

public enum StowerAppBootstrap {
    @MainActor
    public static func makeStore() -> StoreOf<AppFeature> {
        do {
            try prepareDependencies {
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
