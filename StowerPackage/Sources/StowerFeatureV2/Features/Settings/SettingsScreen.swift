import ComposableArchitecture
import SwiftUI

public struct SettingsScreen: View {
    @Bindable var store: StoreOf<SettingsFeature>

    public init(store: StoreOf<SettingsFeature>) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section("Sync") {
                HStack {
                    Text("iCloud Sync")
                    Spacer()
                    Text(syncSummary(store.cloudSyncStatus))
                        .foregroundStyle(.secondary)
                }

                if let detail = syncDetail(store.cloudSyncStatus) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

#if DEBUG
            if let diagnostics = store.diagnostics {
                Section("Sync Diagnostics") {
                    LabeledContent("Synced rows") {
                        Text("\(diagnostics.syncedItemsCount)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Pending changes") {
                        Text("\(diagnostics.pendingChangesCount)")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Metadata rows") {
                        Text("\(diagnostics.metadataCount)")
                            .foregroundStyle(.secondary)
                    }

                    if !diagnostics.sampleItems.isEmpty {
                        Text("Latest synced items")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(diagnostics.sampleItems) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.caption)
                                if let url = item.sourceURL {
                                    Text(url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
#endif

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

    private func syncSummary(_ status: CloudSyncStatus) -> String {
        switch status.state {
        case .starting:
            return "Starting"
        case .available:
            return "On"
        case .unavailable:
            return "Off"
        case .error:
            return "Issue"
        case .needsLocalReset:
            return "Attention"
        }
    }

    private func syncDetail(_ status: CloudSyncStatus) -> String? {
        switch status.state {
        case .starting, .available:
            if let date = status.lastSyncSuccess {
                return "Last synced: \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            if let attempt = status.lastSyncAttempt {
                return "Last attempt: \(attempt.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Syncs your library list across devices on the same iCloud account."
        case .unavailable(let reason):
            return reason
        case .error(let message):
            return message
        case .needsLocalReset(let reason):
            return reason
        }
    }
}
