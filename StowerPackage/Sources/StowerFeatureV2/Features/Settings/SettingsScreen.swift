import ComposableArchitecture
import SwiftUI

public struct SettingsScreen: View {
    @Bindable var store: StoreOf<SettingsFeature>

    public init(store: StoreOf<SettingsFeature>) {
        self.store = store
    }

    public var body: some View {
        Form {
            Toggle(
                "Automatically download images",
                isOn: $store.settings.globalAutoDownload.sending(\.globalAutoDownloadChanged)
            )
            Toggle(
                "Ask before new source downloads",
                isOn: $store.settings.askForNewSources.sending(\.askForNewSourcesChanged)
            )

            if let error = store.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Settings")
        .task {
            store.send(.load)
        }
    }
}
